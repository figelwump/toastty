import AppKit
import CoreState
import Foundation
#if TOASTTY_HAS_GHOSTTY_KIT
import GhosttyKit
#endif

@MainActor
final class TerminalSurfaceController: PanelHostLifecycleControlling {
    private let panelID: UUID
    private weak var delegate: (any TerminalSurfaceControllerDelegate)?
    private let hostedView: NSView
    private weak var activeSourceContainer: NSView?
    private var activeAttachment: PanelHostAttachmentToken?
    private var pendingDetachAttachment: PanelHostAttachmentToken?
    private var pendingDetachTask: Task<Void, Never>?
    private var requestedFocus = false

    #if TOASTTY_HAS_GHOSTTY_KIT
    private let terminalSurfaceScrollView: TerminalSurfaceScrollView
    private let terminalHostView: TerminalHostView
    private var ghosttySurface: ghostty_surface_t?
    private let ghosttyManager = GhosttyRuntimeManager.shared
    private var usesBackingPixelSurfaceSizing = false
    private var hasDeterminedSurfaceSizingMode = false
    private var lastRenderMetrics: GhosttyRenderMetrics?
    private var lastDisplayID: UInt32?
    private var surfaceCreationStabilityPasses = 0
    private var lastSurfaceCreationSignature: SurfaceCreationSignature?
    private var lastSurfaceDeferralReason: SurfaceCreationDeferralReason?
    private var lastViewportDeferralReason: SurfaceCreationDeferralReason?
    private var temporarilyHiddenForViewportDeferral = false
    private var viewportResumeStabilityPasses = 0
    private var lastAttachmentTransitionAt: Date?
    private var lastViewportResumeSignature: SurfaceCreationSignature?
    private var lastPresentationSignature: SurfacePresentationSignature?
    private weak var latestViewportSourceContainer: NSView?
    private var latestViewportUpdate: PendingViewportUpdate?
    private var closeTransitionViewportDeferralArmed = false
    private var closeTransitionViewportUpdatePending = false
    private var closeTransitionViewportReplayTask: Task<Void, Never>?
    private var latestScrollbarState: TerminalScrollbarState?
    private var lastScrollbarUpdateUptimeNanoseconds: UInt64?
    private var focusedPanelViewportBottomAlignmentPending = false
    private var lastBottomAlignmentArmUptimeNanoseconds: UInt64?
    private var lastImmediateSurfaceRefreshTrace: ImmediateSurfaceRefreshTrace?
    private var diagnostics = SurfaceDiagnostics()

    private let minimumSurfaceHostDimension = 48
    private let requiredStableSurfaceCreationPasses = 2
    private let requiredStableViewportResumePasses = 2
    private let requiredAutomationInputStabilityInterval: TimeInterval = 0.5
    private static let scrollToBottomBindingAction = "scroll_to_bottom"

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

    private struct SurfacePresentationSignature: Equatable {
        let logicalWidth: Int
        let logicalHeight: Int
        let pixelWidth: Int
        let pixelHeight: Int
        let scaleThousandths: Int
        let focused: Bool
        let pixelSizingEnabled: Bool
    }

    private struct PendingViewportUpdate {
        let terminalState: TerminalPanelState
        let focused: Bool
        let fontPoints: Double
        let viewportSize: CGSize
        let backingScaleFactor: CGFloat
        let attachment: PanelHostAttachmentToken
    }

    private struct ImmediateSurfaceRefreshTrace {
        let uptimeNanoseconds: UInt64
        let reason: String
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
        var viewportDeferredCount = 0
    }

    private static func currentUptimeNanoseconds() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    private static func deltaMillisecondsString(from earlierNanoseconds: UInt64, to laterNanoseconds: UInt64) -> String {
        let deltaNanoseconds = laterNanoseconds > earlierNanoseconds
            ? laterNanoseconds - earlierNanoseconds
            : 0
        return String(format: "%.3f", Double(deltaNanoseconds) / 1_000_000)
    }
    #endif

    private let fallbackView = TerminalFallbackView()

    init(panelID: UUID, delegate: any TerminalSurfaceControllerDelegate) {
        self.panelID = panelID
        self.delegate = delegate
        #if TOASTTY_HAS_GHOSTTY_KIT
        let surfaceScrollView = TerminalSurfaceScrollView()
        terminalSurfaceScrollView = surfaceScrollView
        terminalHostView = surfaceScrollView.terminalHostView
        hostedView = surfaceScrollView
        terminalHostView.requestFirstResponderIfNeeded = { [weak self] in
            guard let self else { return }
            guard self.requestedFocus && self.terminalHostView.isEffectivelyVisible else {
                return
            }
            _ = self.focusHostViewIfNeeded()
        }
        terminalHostView.resolveImageFileDrop = { [weak self] urls in
            guard let self else { return nil }
            return self.delegate?.prepareImageFileDrop(from: urls, targetPanelID: self.panelID)
        }
        terminalHostView.performImageFileDrop = { [weak self] drop in
            guard let self else { return false }
            return self.delegate?.handlePreparedImageFileDrop(drop) ?? false
        }
        #else
        hostedView = fallbackView
        #endif
    }

    var lifecycleState: PanelHostLifecycleState {
        guard let activeAttachment else {
            return .detached
        }
        let sourceContainer = activeSourceContainer
        let attachedToContainer = sourceContainer != nil && hostedView.superview === sourceContainer
        let attachedToWindow = hostedView.window != nil && sourceContainer?.window != nil
        if pendingDetachAttachment == activeAttachment {
            return .attached(activeAttachment)
        }
        return attachedToContainer && attachedToWindow ? .ready(activeAttachment) : .attached(activeAttachment)
    }

    func attachHost(to container: NSView, attachment: PanelHostAttachmentToken) {
        if let activeAttachment, attachment.generation < activeAttachment.generation {
            ToasttyLog.debug(
                "Ignoring stale panel host attachment",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "attachment_id": attachment.rawValue.uuidString,
                    "attachment_generation": String(attachment.generation),
                    "active_attachment_id": activeAttachment.rawValue.uuidString,
                    "active_attachment_generation": String(activeAttachment.generation)
                ]
            )
            return
        }
        pendingDetachTask?.cancel()
        pendingDetachTask = nil
        pendingDetachAttachment = nil
        let sourceContainerChanged = activeSourceContainer !== container
        let hostedViewWillReattach = hostedView.superview !== container
        let attachmentChanged = activeAttachment != attachment
        // Claim the newest token even if the move is deferred so stale callbacks
        // from the previous SwiftUI container cannot reclaim the host. The
        // controller continues to receive attachHost/update retries while
        // activeSourceContainer still points at the old container.
        activeAttachment = attachment
        #if TOASTTY_HAS_GHOSTTY_KIT
        diagnostics.attachCount += 1
        if shouldDeferHostTransfer(to: container) {
            ToasttyLog.debug(
                "Deferring panel host transfer until replacement container is ready",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "attachment_id": attachment.rawValue.uuidString,
                    "target_has_window": container.window == nil ? "false" : "true",
                    "target_hidden": container.isHidden ? "true" : "false",
                    "target_hidden_ancestor": container.hasHiddenAncestor ? "true" : "false",
                    "target_width": String(format: "%.1f", container.bounds.width),
                    "target_height": String(format: "%.1f", container.bounds.height),
                ]
            )
            return
        }
        #endif

        activeSourceContainer = container
        if hostedViewWillReattach {
            // Let AppKit move the live host view directly between containers.
            // An explicit remove first creates a transient window=nil hop, which
            // drives Ghostty occlusion false/true churn during split remounts.
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
        if sourceContainerChanged || attachmentChanged || hostedViewWillReattach {
            lastAttachmentTransitionAt = Date()
            surfaceCreationStabilityPasses = 0
            lastSurfaceCreationSignature = nil
            lastSurfaceDeferralReason = nil
            refreshSurfaceAfterContainerMove(sourceContainer: container)
        }
        #endif
    }

    #if TOASTTY_HAS_GHOSTTY_KIT
    private func shouldDeferHostTransfer(to container: NSView) -> Bool {
        let minimumHostDimension = 48
        // updateNSView/layout retries attachHost until the source container and
        // hosted view actually converge. Returning true here only preserves the
        // last visible host while the replacement container is still mounting.
        guard activeSourceContainer !== container else {
            return false
        }
        guard hostedView.superview != nil else {
            return false
        }
        guard let currentSourceContainer = activeSourceContainer,
              currentSourceContainer.window != nil,
              currentSourceContainer.isHidden == false,
              currentSourceContainer.hasHiddenAncestor == false else {
            return false
        }
        guard container.window == nil || container.isHidden || container.hasHiddenAncestor else {
            let width = Int(container.bounds.width.rounded(.down))
            let height = Int(container.bounds.height.rounded(.down))
            return width < minimumHostDimension || height < minimumHostDimension
        }
        return true
    }
    #endif

    func detachHost(attachment: PanelHostAttachmentToken) {
        guard let currentAttachment = activeAttachment else { return }
        guard attachment == currentAttachment else {
            if attachment.generation < currentAttachment.generation {
                ToasttyLog.debug(
                    "Ignoring stale panel host detach",
                    category: .terminal,
                    metadata: [
                        "panel_id": panelID.uuidString,
                        "attachment_id": attachment.rawValue.uuidString,
                        "attachment_generation": String(attachment.generation),
                        "active_attachment_id": currentAttachment.rawValue.uuidString,
                        "active_attachment_generation": String(currentAttachment.generation)
                    ]
                )
                return
            }
            ToasttyLog.debug(
                "Ignoring detach for non-current panel host attachment",
                category: .terminal,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "attachment_id": attachment.rawValue.uuidString,
                    "attachment_generation": String(attachment.generation),
                    "active_attachment_id": currentAttachment.rawValue.uuidString,
                    "active_attachment_generation": String(currentAttachment.generation)
                ]
            )
            return
        }
        pendingDetachTask?.cancel()
        pendingDetachAttachment = attachment
        ToasttyLog.debug(
            "Scheduling panel host detach",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "attachment_id": attachment.rawValue.uuidString
            ]
        )
        pendingDetachTask = Task { @MainActor [weak self] in
            // SwiftUI commonly remounts the source panel host when split topology
            // changes. Yield once so a replacement container can claim the stable
            // host view before we tear it down and flash the old panel.
            await Task.yield()
            guard Task.isCancelled == false else { return }
            guard let self,
                  self.pendingDetachAttachment == attachment,
                  self.activeAttachment == attachment else {
                return
            }
            self.pendingDetachTask = nil
            self.pendingDetachAttachment = nil
            self.activeAttachment = nil
            self.activeSourceContainer = nil
            self.hostedView.removeFromSuperview()
            self.fallbackView.removeFromSuperview()
            ToasttyLog.debug(
                "Detaching panel host controller",
                category: .terminal,
                metadata: [
                    "panel_id": self.panelID.uuidString,
                    "attachment_id": attachment.rawValue.uuidString
                ]
            )
        }
    }

    func update(
        terminalState: TerminalPanelState,
        focused: Bool,
        fontPoints: Double,
        viewportSize: CGSize,
        backingScaleFactor: CGFloat,
        sourceContainer: NSView,
        attachment: PanelHostAttachmentToken
    ) {
        guard activeAttachment == attachment,
              pendingDetachAttachment != attachment else {
            ToasttyLog.debug(
                "Skipping terminal update from stale host attachment",
                category: .terminal,
                metadata: ["panel_id": panelID.uuidString]
            )
            return
        }

        #if TOASTTY_HAS_GHOSTTY_KIT
        recordLatestViewportUpdate(
            terminalState: terminalState,
            focused: focused,
            fontPoints: fontPoints,
            viewportSize: viewportSize,
            backingScaleFactor: backingScaleFactor,
            sourceContainer: sourceContainer,
            attachment: attachment
        )
        diagnostics.updateCount += 1
        requestedFocus = focused
        if activeSourceContainer !== sourceContainer || hostedView.superview !== sourceContainer {
            attachHost(to: sourceContainer, attachment: attachment)
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
            if hostedView.isHidden { hostedView.isHidden = false }
            temporarilyHiddenForViewportDeferral = false
            resetViewportResumeStability()
            lastPresentationSignature = nil
            terminalHostView.setGhosttySurface(nil)
            fallbackView.update(terminalState: terminalState, unavailableReason: "Ghostty surface unavailable")
            swapToFallbackIfNeeded()
            return
        }

        terminalHostView.setGhosttySurface(ghosttySurface)
        if fallbackView.superview != nil {
            fallbackView.removeFromSuperview()
        }

        let xScale = max(Double(backingScaleFactor), 1)
        let yScale = max(Double(backingScaleFactor), 1)
        let logicalWidth = max(Int(viewportSize.width.rounded(.down)), 1)
        let logicalHeight = max(Int(viewportSize.height.rounded(.down)), 1)
        let hostView = terminalHostView
        if let viewportDeferralReason = evaluateViewportUpdateReadiness(
            for: hostView,
            width: logicalWidth,
            height: logicalHeight
        ) {
            // For an existing live surface, keeping the last good frame visible
            // is less disruptive than blanking the source panel during split
            // remount churn. Newly created surfaces still stay hidden until the
            // first stable viewport arrives.
            if lastPresentationSignature == nil, hostedView.isHidden == false {
                hostedView.isHidden = true
            }
            temporarilyHiddenForViewportDeferral = true
            diagnostics.viewportDeferredCount += 1
            let reasonChanged = lastViewportDeferralReason != viewportDeferralReason
            lastViewportDeferralReason = viewportDeferralReason
            if reasonChanged || diagnostics.viewportDeferredCount <= 2 || diagnostics.viewportDeferredCount.isMultiple(of: 60) {
                logSurfaceDiagnostics(
                    message: "Deferring Ghostty viewport update until host is stable",
                    extra: [
                        "reason": viewportDeferralReason.rawValue,
                        "viewport_width": String(logicalWidth),
                        "viewport_height": String(logicalHeight),
                    ]
                )
            }
            return
        }
        let resumedFromViewportDeferral = lastViewportDeferralReason != nil
        lastViewportDeferralReason = nil
        updateDisplayIDIfNeeded(surface: ghosttySurface, sourceContainer: sourceContainer)
        ghostty_surface_set_content_scale(ghosttySurface, xScale, yScale)
        let pixelWidth = max(Int((viewportSize.width * backingScaleFactor).rounded()), 1)
        let pixelHeight = max(Int((viewportSize.height * backingScaleFactor).rounded()), 1)
        if shouldDeferCloseTransitionViewportResize(
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight
        ) {
            return
        }
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
        if hostedView.isHidden { hostedView.isHidden = false }
        temporarilyHiddenForViewportDeferral = false
        resetViewportResumeStability()
        let hostVisible = hostView.synchronizePresentationVisibility(reason: "controller_update")
        let requestedFocused = focused && hostVisible
        ensureFirstResponderIfNeeded(focused: requestedFocused)
        let resolvedFocused: Bool
        if requestedFocused {
            resolvedFocused = hostView.resolvedGhosttySurfaceFocusState()
            hostView.syncSurfaceFocus(
                resolvedFocused,
                reason: "controller_update"
            )
        } else {
            resolvedFocused = false
            hostView.syncSurfaceFocus(
                false,
                reason: "controller_update"
            )
        }

        let presentationSignature = SurfacePresentationSignature(
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            scaleThousandths: Int((xScale * 1000).rounded()),
            focused: resolvedFocused,
            pixelSizingEnabled: usesBackingPixelSurfaceSizing
        )
        let presentationChanged = presentationSignature != lastPresentationSignature
        lastPresentationSignature = presentationSignature

        let didApplyFocusedPanelViewportBottomAlignment = applyFocusedPanelViewportBottomAlignmentIfNeeded(
            on: ghosttySurface,
            logicalWidth: logicalWidth,
            logicalHeight: logicalHeight
        )
        if hostVisible && (resumedFromViewportDeferral || presentationChanged) {
            requestImmediateSurfaceRefresh(
                ghosttySurface,
                reason: resumedFromViewportDeferral ? "viewport_resume" : "presentation_change",
                extra: [
                    "focused": resolvedFocused ? "true" : "false",
                    "logical_width": String(logicalWidth),
                    "logical_height": String(logicalHeight),
                    "pixel_width": String(pixelWidth),
                    "pixel_height": String(pixelHeight),
                ]
            )
        }
        if didApplyFocusedPanelViewportBottomAlignment {
            requestImmediateSurfaceRefresh(
                ghosttySurface,
                reason: "focused_panel_viewport_bottom_alignment",
                extra: [
                    "logical_width": String(logicalWidth),
                    "logical_height": String(logicalHeight),
                    "scrollbar_total": latestScrollbarState.map { String($0.total) } ?? "nil",
                    "scrollbar_offset": latestScrollbarState.map { String($0.offset) } ?? "nil",
                    "scrollbar_visible_length": latestScrollbarState.map { String($0.visibleLength) } ?? "nil",
                ]
            )
        }
        #else
        fallbackView.update(terminalState: terminalState, unavailableReason: "Ghostty terminal runtime not enabled in this build")
        #endif
    }

    func invalidate() {
        ToasttyLog.debug(
            "Invalidating panel host controller",
            category: .terminal,
            metadata: [
                "panel_id": panelID.uuidString,
                "attachment_id": activeAttachment?.rawValue.uuidString ?? "nil",
                "has_source_container": activeSourceContainer == nil ? "false" : "true"
            ]
        )
        pendingDetachTask?.cancel()
        pendingDetachTask = nil
        pendingDetachAttachment = nil
        #if TOASTTY_HAS_GHOSTTY_KIT
        terminalHostView.setGhosttySurface(nil)
        if let ghosttySurface {
            ghosttyManager.unregisterSurfaceAssociation(forHostView: terminalHostView, surface: ghosttySurface)
            delegate?.unregisterSurfaceHandle(ghosttySurface, for: panelID)
            ghostty_surface_free(ghosttySurface)
            self.ghosttySurface = nil
        }
        usesBackingPixelSurfaceSizing = false
        hasDeterminedSurfaceSizingMode = false
        lastRenderMetrics = nil
        lastDisplayID = nil
        surfaceCreationStabilityPasses = 0
        lastSurfaceCreationSignature = nil
        lastSurfaceDeferralReason = nil
        lastViewportDeferralReason = nil
        temporarilyHiddenForViewportDeferral = false
        lastAttachmentTransitionAt = nil
        resetViewportResumeStability()
        lastPresentationSignature = nil
        latestViewportSourceContainer = nil
        latestViewportUpdate = nil
        closeTransitionViewportReplayTask?.cancel()
        closeTransitionViewportReplayTask = nil
        closeTransitionViewportDeferralArmed = false
        closeTransitionViewportUpdatePending = false
        latestScrollbarState = nil
        lastScrollbarUpdateUptimeNanoseconds = nil
        focusedPanelViewportBottomAlignmentPending = false
        lastBottomAlignmentArmUptimeNanoseconds = nil
        lastImmediateSurfaceRefreshTrace = nil
        diagnostics = SurfaceDiagnostics()
        #endif
        activeSourceContainer = nil
        activeAttachment = nil
        requestedFocus = false
        fallbackView.removeFromSuperview()
        hostedView.removeFromSuperview()
    }

    @discardableResult
    func focusHostViewIfNeeded() -> Bool {
        guard let window = hostedView.window else { return false }
        #if TOASTTY_HAS_GHOSTTY_KIT
        let focusTarget = terminalHostView
        #else
        let focusTarget = hostedView
        #endif
        let didFocus: Bool
        if window.firstResponder === focusTarget {
            didFocus = true
        } else {
            didFocus = window.makeFirstResponder(focusTarget)
        }
        #if TOASTTY_HAS_GHOSTTY_KIT
        if didFocus {
            terminalHostView.synchronizeGhosttySurfaceFocusFromApplicationState()
        }
        #endif
        return didFocus
    }

    func automationSendText(_ text: String, submit: Bool) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        // Automation input should follow actual surface/host readiness. Process
        // cwd inference can lag behind fresh split creation and block panels
        // that are already interactive from Ghostty's perspective.
        guard let ghosttySurface, isReadyForAutomationInput(), focusHostViewIfNeeded() else {
            return false
        }

        if text.isEmpty == false {
            sendSurfaceText(text, to: ghosttySurface)
        }

        if submit {
            guard sendSurfaceSubmit(to: ghosttySurface) else {
                return false
            }
        }

        return true
        #else
        return false
        #endif
    }

    private func isReadyForAutomationInput(now: Date = Date()) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard lifecycleState.isReadyForFocus else {
            return false
        }
        guard ghosttySurface != nil else {
            return false
        }
        guard temporarilyHiddenForViewportDeferral == false else {
            return false
        }
        if let lastAttachmentTransitionAt,
           now.timeIntervalSince(lastAttachmentTransitionAt) < requiredAutomationInputStabilityInterval {
            return false
        }
        return true
        #else
        return lifecycleState.isReadyForFocus
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

    func canAcceptImageFileDrop() -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        return ghosttySurface != nil
        #else
        return false
        #endif
    }

    func renderAttachmentSnapshot() -> TerminalPanelRenderAttachmentSnapshot {
        let sourceContainer = activeSourceContainer
        #if TOASTTY_HAS_GHOSTTY_KIT
        let ghosttySurfaceAvailable = ghosttySurface != nil
        #else
        let ghosttySurfaceAvailable = false
        #endif
        return TerminalPanelRenderAttachmentSnapshot(
            panelID: panelID,
            controllerExists: true,
            hostHasSuperview: hostedView.superview != nil,
            hostAttachedToWindow: hostedView.window != nil,
            sourceContainerExists: sourceContainer != nil,
            sourceContainerAttachedToWindow: sourceContainer?.window != nil,
            hostSuperviewMatchesSourceContainer: hostedView.superview === sourceContainer,
            lifecycleState: lifecycleState,
            ghosttySurfaceAvailable: ghosttySurfaceAvailable
        )
    }

    func handleImageFileDrop(_ imageFileURLs: [URL]) -> Bool {
        #if TOASTTY_HAS_GHOSTTY_KIT
        guard let ghosttySurface else {
            return false
        }
        let filePaths = imageFileURLs.map { $0.path(percentEncoded: false) }
        guard let payload = TerminalDropPayloadBuilder.shellEscapedPathPayload(
            forFilePaths: filePaths
        ) else {
            ToasttyLog.warning(
                "Rejected image file drop due to invalid file path payload",
                category: .input,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "image_count": String(imageFileURLs.count),
                ]
            )
            return false
        }
        sendSurfaceText(payload, to: ghosttySurface)
        return true
        #else
        _ = imageFileURLs
        return false
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

    private func sendSurfaceSubmit(to surface: ghostty_surface_t) -> Bool {
        // `ghostty_surface_text` is paste-oriented input. Use a real Return key
        // event so automation submit executes the pending command under bracketed
        // paste and matches live keyboard behavior.
        let submitText = "\r"
        return submitText.withCString { pointer in
            let keyEvent = ghostty_input_key_s(
                action: GHOSTTY_ACTION_PRESS,
                mods: ghostty_input_mods_e(0),
                consumed_mods: ghostty_input_mods_e(0),
                keycode: 0x24,
                text: pointer,
                unshifted_codepoint: 13,
                composing: false
            )
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    func applyGhosttyGlobalFontChange(from previousPoints: Double, to nextPoints: Double) {
        guard let ghosttySurface else { return }
        guard abs(nextPoints - previousPoints) >= AppState.terminalFontComparisonEpsilon else { return }

        let baselinePoints = resolvedGhosttyConfiguredFontBaselinePoints()

        if abs(nextPoints - baselinePoints) < AppState.terminalFontComparisonEpsilon {
            _ = invokeGhosttyBindingAction("reset_font_size", on: ghosttySurface)
            return
        }

        let pointDelta = nextPoints - previousPoints
        let stepMagnitude = max(
            Int(round(abs(pointDelta) / AppState.terminalFontStepPoints)),
            1
        )
        let action = pointDelta > 0
            ? "increase_font_size:\(stepMagnitude)"
            : "decrease_font_size:\(stepMagnitude)"
        _ = invokeGhosttyBindingAction(action, on: ghosttySurface)
    }

    func currentGhosttySurface() -> ghostty_surface_t? {
        ghosttySurface
    }

    private func resolvedGhosttyConfiguredFontBaselinePoints() -> Double {
        let configuredPoints = ghosttyManager.configuredTerminalFontPoints ?? AppState.defaultTerminalFontPoints
        return AppState.clampedTerminalFontPoints(configuredPoints)
    }

    private func synchronizeGhosttySurfaceFont(to targetPoints: Double, on surface: ghostty_surface_t) {
        let baselinePoints = resolvedGhosttyConfiguredFontBaselinePoints()
        let clampedTargetPoints = AppState.clampedTerminalFontPoints(targetPoints)

        if abs(clampedTargetPoints - baselinePoints) < AppState.terminalFontComparisonEpsilon {
            _ = invokeGhosttyBindingAction("reset_font_size", on: surface)
            return
        }

        // Normalize to Ghostty's configured baseline before applying a delta so
        // newly created panes don't retain stale inherited zoom levels.
        guard invokeGhosttyBindingAction("reset_font_size", on: surface) else {
            return
        }

        let pointDelta = clampedTargetPoints - baselinePoints
        let stepMagnitude = max(
            Int(round(abs(pointDelta) / AppState.terminalFontStepPoints)),
            1
        )
        let action = pointDelta > 0
            ? "increase_font_size:\(stepMagnitude)"
            : "decrease_font_size:\(stepMagnitude)"
        _ = invokeGhosttyBindingAction(action, on: surface)
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
        guard let delegate else { return }

        let hostView = terminalHostView

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

        let inheritedSourceSurface: ghostty_surface_t?
        switch delegate.splitSourceSurfaceState(forNewPanelID: panelID) {
        case .none:
            inheritedSourceSurface = nil
        case .pending:
            diagnostics.surfaceDeferredCount += 1
            if diagnostics.surfaceDeferredCount <= 2 || diagnostics.surfaceDeferredCount.isMultiple(of: 60) {
                logSurfaceDiagnostics(
                    message: "Deferring split surface creation until source surface is available",
                    extra: ["reason": "pending_split_source_surface"]
                )
            }
            return
        case .ready(let sourcePanelID, let sourceSurface):
            inheritedSourceSurface = sourceSurface
            ToasttyLog.debug(
                "Using source Ghostty surface for split inheritance",
                category: .terminal,
                metadata: [
                    "source_panel_id": sourcePanelID.uuidString,
                    "new_panel_id": panelID.uuidString,
                ]
            )
        }

        // Launch the shell from a separate seed instead of the live cwd field.
        // Restored panes intentionally start with blank live cwd and wait for
        // runtime metadata to repopulate it authoritatively.
        let requestedWorkingDirectory = terminalState.workingDirectorySeed

        // Snapshot child PIDs before surface creation so we can diff after
        // to find the newly spawned login/shell process for CWD tracking.
        let previousChildPIDs = delegate.surfaceCreationChildPIDSnapshot()
        let launchConfiguration = delegate.surfaceLaunchConfiguration(for: panelID)

        diagnostics.surfaceAttemptCount += 1
        guard let createdSurface = ghosttyManager.makeSurface(
            hostView: hostView,
            workingDirectory: requestedWorkingDirectory,
            fontPoints: fontPoints,
            inheritFrom: inheritedSourceSurface,
            launchConfiguration: launchConfiguration
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
        let surface = createdSurface.surface
        diagnostics.surfaceSuccessCount += 1
        if inheritedSourceSurface != nil {
            delegate.consumeSplitSource(forNewPanelID: panelID)
        }
        lastSurfaceDeferralReason = nil
        lastViewportDeferralReason = nil
        surfaceCreationStabilityPasses = 0
        lastSurfaceCreationSignature = nil
        lastPresentationSignature = nil
        logSurfaceDiagnostics(message: "Ghostty surface creation succeeded")
        usesBackingPixelSurfaceSizing = false
        hasDeterminedSurfaceSizingMode = false
        lastRenderMetrics = nil
        lastDisplayID = nil
        ghosttySurface = surface
        delegate.registerSurfaceHandle(surface, for: panelID)
        synchronizeGhosttySurfaceFont(to: fontPoints, on: surface)

        // Register the new child process (login → shell) for CWD tracking.
        delegate.registerSurfaceChildPIDAfterCreation(
            panelID: panelID,
            previousChildren: previousChildPIDs,
            expectedWorkingDirectory: terminalState.expectedProcessWorkingDirectory
        )

        // The requested cwd is just launch config, not authoritative live shell
        // state. Ask metadata to refresh from the spawned child process instead.
        delegate.requestImmediateProcessWorkingDirectoryRefresh(
            panelID: panelID,
            source: "surface_create_process"
        )
        delegate.markInitialSurfaceLaunchCompleted(for: panelID)
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

    private func evaluateViewportUpdateReadiness(
        for hostView: NSView,
        width: Int,
        height: Int
    ) -> SurfaceCreationDeferralReason? {
        guard let window = hostView.window else {
            resetViewportResumeStability()
            return .noWindow
        }

        guard hostView.hasHiddenAncestor == false else {
            resetViewportResumeStability()
            return .hiddenHost
        }

        if hostView.isHidden, temporarilyHiddenForViewportDeferral == false {
            resetViewportResumeStability()
            return .hiddenHost
        }

        guard width >= minimumSurfaceHostDimension,
              height >= minimumSurfaceHostDimension else {
            resetViewportResumeStability()
            return .tinyBounds
        }

        if temporarilyHiddenForViewportDeferral {
            let signature = SurfaceCreationSignature(
                windowID: ObjectIdentifier(window),
                width: width,
                height: height
            )
            if lastViewportResumeSignature == signature {
                viewportResumeStabilityPasses += 1
            } else {
                lastViewportResumeSignature = signature
                viewportResumeStabilityPasses = 1
            }

            guard viewportResumeStabilityPasses >= requiredStableViewportResumePasses else {
                return .unstableBounds
            }
        } else {
            resetViewportResumeStability()
        }

        return nil
    }

    private func resetViewportResumeStability() {
        viewportResumeStabilityPasses = 0
        lastViewportResumeSignature = nil
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
            "viewport_deferred_count": String(diagnostics.viewportDeferredCount),
        ]
        for (key, value) in extra {
            metadata[key] = value
        }
        ToasttyLog.debug(message, category: .ghostty, metadata: metadata)
    }

    func updateScrollbarState(_ state: TerminalScrollbarState) {
        let previousState = latestScrollbarState
        let previousUpdateUptimeNanoseconds = lastScrollbarUpdateUptimeNanoseconds
        latestScrollbarState = state
        let nowNanoseconds = Self.currentUptimeNanoseconds()
        lastScrollbarUpdateUptimeNanoseconds = nowNanoseconds
        guard previousState != state else {
            return
        }
        var metadata: [String: String] = [
            "panel_id": panelID.uuidString,
            "scrollbar_total": String(state.total),
            "scrollbar_offset": String(state.offset),
            "scrollbar_visible_length": String(state.visibleLength),
            "scrollbar_trailing_edge": String(state.trailingEdge),
            "scrollbar_pinned_to_bottom": state.isPinnedToBottom ? "true" : "false",
        ]
        if let previousState {
            metadata["previous_scrollbar_total"] = String(previousState.total)
            metadata["previous_scrollbar_offset"] = String(previousState.offset)
            metadata["previous_scrollbar_visible_length"] = String(previousState.visibleLength)
            metadata["previous_scrollbar_pinned_to_bottom"] = previousState.isPinnedToBottom ? "true" : "false"
        }
        if let previousUpdateUptimeNanoseconds {
            metadata["delta_ms_since_last_scrollbar_update"] = Self.deltaMillisecondsString(
                from: previousUpdateUptimeNanoseconds,
                to: nowNanoseconds
            )
        }
        ToasttyLog.debug(
            "Updated terminal scrollbar state",
            category: .ghostty,
            metadata: metadata
        )
    }

    var currentScrollbarState: TerminalScrollbarState? {
        latestScrollbarState
    }

    func armFocusedPanelViewportBottomAlignmentIfNeeded() {
        let nowNanoseconds = Self.currentUptimeNanoseconds()
        guard let latestScrollbarState else {
            focusedPanelViewportBottomAlignmentPending = false
            lastBottomAlignmentArmUptimeNanoseconds = nil
            ToasttyLog.debug(
                "Skipped focused panel viewport bottom alignment",
                category: .ghostty,
                metadata: [
                    "panel_id": panelID.uuidString,
                    "reason": "missing_scrollbar_state",
                ]
            )
            return
        }
        guard latestScrollbarState.isPinnedToBottom else {
            focusedPanelViewportBottomAlignmentPending = false
            lastBottomAlignmentArmUptimeNanoseconds = nil
            var metadata: [String: String] = [
                "panel_id": panelID.uuidString,
                "reason": "scrollbar_not_pinned_to_bottom",
                "scrollbar_total": String(latestScrollbarState.total),
                "scrollbar_offset": String(latestScrollbarState.offset),
                "scrollbar_visible_length": String(latestScrollbarState.visibleLength),
                "scrollbar_trailing_edge": String(latestScrollbarState.trailingEdge),
                "scrollbar_pinned_to_bottom": "false",
            ]
            if let lastScrollbarUpdateUptimeNanoseconds {
                metadata["delta_ms_since_last_scrollbar_update"] = Self.deltaMillisecondsString(
                    from: lastScrollbarUpdateUptimeNanoseconds,
                    to: nowNanoseconds
                )
            }
            ToasttyLog.debug(
                "Skipped focused panel viewport bottom alignment",
                category: .ghostty,
                metadata: metadata
            )
            return
        }
        focusedPanelViewportBottomAlignmentPending = true
        lastBottomAlignmentArmUptimeNanoseconds = nowNanoseconds
        var metadata: [String: String] = [
            "panel_id": panelID.uuidString,
            "scrollbar_total": String(latestScrollbarState.total),
            "scrollbar_offset": String(latestScrollbarState.offset),
            "scrollbar_visible_length": String(latestScrollbarState.visibleLength),
            "scrollbar_trailing_edge": String(latestScrollbarState.trailingEdge),
            "scrollbar_pinned_to_bottom": "true",
        ]
        if let lastScrollbarUpdateUptimeNanoseconds {
            metadata["delta_ms_since_last_scrollbar_update"] = Self.deltaMillisecondsString(
                from: lastScrollbarUpdateUptimeNanoseconds,
                to: nowNanoseconds
            )
        }
        ToasttyLog.debug(
            "Armed focused panel viewport bottom alignment",
            category: .ghostty,
            metadata: metadata
        )
    }

    var isFocusedPanelViewportBottomAlignmentPending: Bool {
        focusedPanelViewportBottomAlignmentPending
    }
    #endif
}

@MainActor
extension TerminalSurfaceController {
    #if TOASTTY_HAS_GHOSTTY_KIT
    private func refreshSurfaceAfterContainerMove(sourceContainer: NSView) {
        guard let ghosttySurface else { return }
        updateDisplayIDIfNeeded(surface: ghosttySurface, sourceContainer: sourceContainer)
        requestImmediateSurfaceRefresh(
            ghosttySurface,
            reason: "container_move",
            extra: [
                "container_has_window": sourceContainer.window == nil ? "false" : "true",
                "container_hidden": sourceContainer.isHidden ? "true" : "false",
                "container_hidden_ancestor": sourceContainer.hasHiddenAncestor ? "true" : "false",
                "container_width": String(format: "%.1f", sourceContainer.bounds.width),
                "container_height": String(format: "%.1f", sourceContainer.bounds.height),
            ]
        )
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
        #if TOASTTY_HAS_GHOSTTY_KIT
        let focusTarget = terminalHostView
        #else
        let focusTarget = hostedView
        #endif
        guard window.firstResponder !== focusTarget else { return }
        window.makeFirstResponder(focusTarget)
    }

    func pulseVisibilityRefresh() {
        guard let ghosttySurface else { return }
        guard terminalHostView.synchronizePresentationVisibility(reason: "visibility_pulse") else {
            return
        }
        requestImmediateSurfaceRefresh(
            ghosttySurface,
            reason: "visibility_pulse",
            extra: [
                "host_effectively_visible": terminalHostView.isEffectivelyVisible ? "true" : "false",
                "lifecycle_state": lifecycleState.automationLabel,
            ]
        )
    }

    // Closing a split can briefly produce an intermediate resize before the
    // surviving pane settles into its final frame. Replay the latest viewport
    // one turn later so Ghostty only sees the stabilized size.
    func armCloseTransitionViewportDeferral() {
        closeTransitionViewportReplayTask?.cancel()
        closeTransitionViewportDeferralArmed = true
        closeTransitionViewportUpdatePending = false
        closeTransitionViewportReplayTask = Task { @MainActor [weak self] in
            await Task.yield()
            guard Task.isCancelled == false else { return }
            guard let self else { return }
            self.closeTransitionViewportReplayTask = nil
            guard self.closeTransitionViewportDeferralArmed else { return }
            let shouldReplay = self.closeTransitionViewportUpdatePending
            self.closeTransitionViewportDeferralArmed = false
            self.closeTransitionViewportUpdatePending = false
            guard shouldReplay else { return }
            self.replayDeferredViewportUpdateIfNeeded()
        }
    }

    var isCloseTransitionViewportDeferralArmed: Bool {
        closeTransitionViewportDeferralArmed
    }

    private func requestImmediateSurfaceRefresh(
        _ surface: ghostty_surface_t,
        reason: String,
        extra: [String: String] = [:]
    ) {
        let nowNanoseconds = Self.currentUptimeNanoseconds()
        var metadata: [String: String] = [
            "panel_id": panelID.uuidString,
            "reason": reason,
            "host_effectively_visible": terminalHostView.isEffectivelyVisible ? "true" : "false",
        ]
        if let latestScrollbarState {
            metadata["scrollbar_total"] = String(latestScrollbarState.total)
            metadata["scrollbar_offset"] = String(latestScrollbarState.offset)
            metadata["scrollbar_visible_length"] = String(latestScrollbarState.visibleLength)
            metadata["scrollbar_pinned_to_bottom"] = latestScrollbarState.isPinnedToBottom ? "true" : "false"
        }
        if let lastScrollbarUpdateUptimeNanoseconds {
            metadata["delta_ms_since_last_scrollbar_update"] = Self.deltaMillisecondsString(
                from: lastScrollbarUpdateUptimeNanoseconds,
                to: nowNanoseconds
            )
        }
        if let lastBottomAlignmentArmUptimeNanoseconds {
            metadata["delta_ms_since_bottom_alignment_arm"] = Self.deltaMillisecondsString(
                from: lastBottomAlignmentArmUptimeNanoseconds,
                to: nowNanoseconds
            )
        }
        if let lastImmediateSurfaceRefreshTrace {
            metadata["delta_ms_since_last_immediate_refresh"] = Self.deltaMillisecondsString(
                from: lastImmediateSurfaceRefreshTrace.uptimeNanoseconds,
                to: nowNanoseconds
            )
            metadata["previous_immediate_refresh_reason"] = lastImmediateSurfaceRefreshTrace.reason
        }
        for (key, value) in terminalHostView.recentTypingTraceMetadata(nowNanoseconds: nowNanoseconds) {
            metadata[key] = value
        }
        for (key, value) in extra {
            metadata[key] = value
        }
        ToasttyLog.debug(
            "Requesting immediate Ghostty surface refresh",
            category: .ghostty,
            metadata: metadata
        )
        lastImmediateSurfaceRefreshTrace = ImmediateSurfaceRefreshTrace(
            uptimeNanoseconds: nowNanoseconds,
            reason: reason
        )
        ghosttyManager.requestImmediateTick()
        ghostty_surface_refresh(surface)
    }

    func synchronizeGhosttySurfaceFocusFromApplicationState() {
        terminalHostView.synchronizeGhosttySurfaceFocusFromApplicationState()
    }

    private func recordLatestViewportUpdate(
        terminalState: TerminalPanelState,
        focused: Bool,
        fontPoints: Double,
        viewportSize: CGSize,
        backingScaleFactor: CGFloat,
        sourceContainer: NSView,
        attachment: PanelHostAttachmentToken
    ) {
        latestViewportSourceContainer = sourceContainer
        latestViewportUpdate = PendingViewportUpdate(
            terminalState: terminalState,
            focused: focused,
            fontPoints: fontPoints,
            viewportSize: viewportSize,
            backingScaleFactor: backingScaleFactor,
            attachment: attachment
        )
    }

    private func applyFocusedPanelViewportBottomAlignmentIfNeeded(
        on surface: ghostty_surface_t,
        logicalWidth: Int,
        logicalHeight: Int
    ) -> Bool {
        guard focusedPanelViewportBottomAlignmentPending else {
            return false
        }
        focusedPanelViewportBottomAlignmentPending = false
        let nowNanoseconds = Self.currentUptimeNanoseconds()
        let handled = invokeGhosttyBindingAction(Self.scrollToBottomBindingAction, on: surface)
        var metadata: [String: String] = [
            "panel_id": panelID.uuidString,
            "logical_width": String(logicalWidth),
            "logical_height": String(logicalHeight),
            "handled": handled ? "true" : "false",
            "scrollbar_total": latestScrollbarState.map { String($0.total) } ?? "nil",
            "scrollbar_offset": latestScrollbarState.map { String($0.offset) } ?? "nil",
            "scrollbar_visible_length": latestScrollbarState.map { String($0.visibleLength) } ?? "nil",
            "scrollbar_pinned_to_bottom": latestScrollbarState.map { $0.isPinnedToBottom ? "true" : "false" } ?? "nil",
        ]
        if let lastScrollbarUpdateUptimeNanoseconds {
            metadata["delta_ms_since_last_scrollbar_update"] = Self.deltaMillisecondsString(
                from: lastScrollbarUpdateUptimeNanoseconds,
                to: nowNanoseconds
            )
        }
        if let lastBottomAlignmentArmUptimeNanoseconds {
            metadata["delta_ms_since_bottom_alignment_arm"] = Self.deltaMillisecondsString(
                from: lastBottomAlignmentArmUptimeNanoseconds,
                to: nowNanoseconds
            )
        }
        for (key, value) in terminalHostView.recentTypingTraceMetadata(nowNanoseconds: nowNanoseconds) {
            metadata[key] = value
        }
        ToasttyLog.debug(
            handled
                ? "Aligned focused panel viewport to the terminal bottom after focus-mode toggle"
                : "Focused panel viewport bottom alignment binding was not handled",
            category: .ghostty,
            metadata: metadata
        )
        return handled
    }

    private func shouldDeferCloseTransitionViewportResize(
        logicalWidth: Int,
        logicalHeight: Int,
        pixelWidth: Int,
        pixelHeight: Int
    ) -> Bool {
        guard closeTransitionViewportDeferralArmed,
              let lastPresentationSignature else {
            return false
        }
        let logicalSizeChanged = lastPresentationSignature.logicalWidth != logicalWidth ||
            lastPresentationSignature.logicalHeight != logicalHeight
        let pixelSizeChanged = lastPresentationSignature.pixelWidth != pixelWidth ||
            lastPresentationSignature.pixelHeight != pixelHeight
        guard logicalSizeChanged || pixelSizeChanged else {
            return false
        }
        closeTransitionViewportUpdatePending = true
        logSurfaceDiagnostics(
            message: "Deferring Ghostty viewport resize during close-transition layout churn",
            extra: [
                "last_logical_width": String(lastPresentationSignature.logicalWidth),
                "last_logical_height": String(lastPresentationSignature.logicalHeight),
                "next_logical_width": String(logicalWidth),
                "next_logical_height": String(logicalHeight),
                "last_pixel_width": String(lastPresentationSignature.pixelWidth),
                "last_pixel_height": String(lastPresentationSignature.pixelHeight),
                "next_pixel_width": String(pixelWidth),
                "next_pixel_height": String(pixelHeight),
            ]
        )
        return true
    }

    private func replayDeferredViewportUpdateIfNeeded() {
        guard let pendingViewportUpdate = latestViewportUpdate,
              let sourceContainer = latestViewportSourceContainer else {
            return
        }
        update(
            terminalState: pendingViewportUpdate.terminalState,
            focused: pendingViewportUpdate.focused,
            fontPoints: pendingViewportUpdate.fontPoints,
            viewportSize: pendingViewportUpdate.viewportSize,
            backingScaleFactor: pendingViewportUpdate.backingScaleFactor,
            sourceContainer: sourceContainer,
            attachment: pendingViewportUpdate.attachment
        )
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
