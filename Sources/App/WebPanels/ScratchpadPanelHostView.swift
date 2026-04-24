import AppKit
import CoreState
import SwiftUI

struct ScratchpadPanelHostView: NSViewRepresentable {
    typealias MainActorScheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

    @ObservedObject var runtime: ScratchpadPanelRuntime
    let webState: WebPanelState
    let isEffectivelyVisible: Bool
    let isActivePanel: Bool

    @MainActor
    final class Coordinator {
        private static let maxDeferredFocusAttempts = 4

        let containerCoordinator = PanelHostContainerCoordinator()
        var lastAppliedWebState: WebPanelState?
        var lastIsActivePanel = false
        private var pendingWebState: WebPanelState?
        private var pendingApplyRequestID: UUID?
        private var pendingFocusRequestID: UUID?
        private var pendingFocusAttempt = 0
        private let scheduleOnMainActor: MainActorScheduler

        init(
            scheduleOnMainActor: @escaping MainActorScheduler = { operation in
                Task { @MainActor in
                    operation()
                }
            }
        ) {
            self.scheduleOnMainActor = scheduleOnMainActor
        }

        func scheduleApply(webState: WebPanelState, runtime: ScratchpadPanelRuntime) {
            guard lastAppliedWebState != webState,
                  pendingWebState != webState else {
                return
            }

            pendingWebState = webState
            let requestID = UUID()
            pendingApplyRequestID = requestID

            scheduleOnMainActor { [weak self, weak runtime] in
                guard let self,
                      self.pendingApplyRequestID == requestID,
                      self.pendingWebState == webState else {
                    return
                }

                self.pendingApplyRequestID = nil
                self.pendingWebState = nil
                self.lastAppliedWebState = webState
                runtime?.apply(webState: webState)
            }
        }

        func requestFocusIfNeeded(
            isActivePanel: Bool,
            runtime: ScratchpadPanelRuntime
        ) {
            let shouldRequestFocus = isActivePanel && lastIsActivePanel == false
            lastIsActivePanel = isActivePanel

            guard isActivePanel else {
                resetPendingFocusRequest()
                return
            }
            guard shouldRequestFocus else {
                return
            }
            if runtime.focusWebView() {
                resetPendingFocusRequest()
                return
            }
            scheduleDeferredFocusRequest(runtime: runtime)
        }

        func retryPendingFocusIfNeeded(
            isActivePanel: Bool,
            runtime: ScratchpadPanelRuntime
        ) {
            guard isActivePanel,
                  pendingFocusRequestID != nil else {
                return
            }
            if runtime.focusWebView() {
                resetPendingFocusRequest()
            }
        }

        private func scheduleDeferredFocusRequest(runtime: ScratchpadPanelRuntime) {
            let nextAttempt = pendingFocusAttempt + 1
            guard nextAttempt <= Self.maxDeferredFocusAttempts else {
                resetPendingFocusRequest()
                return
            }

            let requestID = pendingFocusRequestID ?? UUID()
            pendingFocusRequestID = requestID
            pendingFocusAttempt = nextAttempt

            scheduleOnMainActor { [weak self, weak runtime] in
                guard let self,
                      self.pendingFocusRequestID == requestID,
                      self.lastIsActivePanel,
                      let runtime else {
                    return
                }

                if runtime.focusWebView() {
                    self.resetPendingFocusRequest()
                    return
                }

                guard self.pendingFocusRequestID == requestID,
                      self.pendingFocusAttempt == nextAttempt else {
                    return
                }
                self.scheduleDeferredFocusRequest(runtime: runtime)
            }
        }

        private func resetPendingFocusRequest() {
            pendingFocusRequestID = nil
            pendingFocusAttempt = 0
        }

        func reset() {
            containerCoordinator.reset()
            lastAppliedWebState = nil
            lastIsActivePanel = false
            pendingWebState = nil
            pendingApplyRequestID = nil
            resetPendingFocusRequest()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WebPanelContainerView {
        WebPanelContainerView()
    }

    func updateNSView(_ containerView: WebPanelContainerView, context: Context) {
        let attachment = context.coordinator.containerCoordinator.attachment(
            for: containerView,
            controller: runtime
        )

        containerView.onEffectiveAppearanceChange = { appearance in
            runtime.applyEffectiveAppearance(appearance)
        }

        let attach = { (view: NSView) in
            runtime.attachHost(to: view, attachment: attachment)
            context.coordinator.retryPendingFocusIfNeeded(
                isActivePanel: isActivePanel,
                runtime: runtime
            )
        }

        containerView.onLayout = attach
        attach(containerView)
        runtime.setEffectivelyVisible(isEffectivelyVisible)
        runtime.applyEffectiveAppearance(containerView.effectiveAppearance)
        context.coordinator.scheduleApply(webState: webState, runtime: runtime)
        context.coordinator.requestFocusIfNeeded(
            isActivePanel: isActivePanel,
            runtime: runtime
        )
    }

    static func dismantleNSView(_ containerView: WebPanelContainerView, coordinator: Coordinator) {
        containerView.onLayout = nil
        containerView.onEffectiveAppearanceChange = nil
        coordinator.reset()
    }
}
