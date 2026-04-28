import AppKit
import CoreState
import SwiftUI

struct BrowserPanelHostView: NSViewRepresentable {
    @ObservedObject var runtime: BrowserPanelRuntime
    let webState: WebPanelState
    let isEffectivelyVisible: Bool
    let shouldFocusWebView: Bool

    @MainActor
    final class Coordinator {
        typealias MainActorScheduler = (@escaping @MainActor @Sendable () -> Void) -> Void
        private static let maxDeferredFocusAttempts = 4

        let containerCoordinator = PanelHostContainerCoordinator()
        var lastAppliedWebState: WebPanelState?
        var lastShouldFocusWebView = false
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

        func scheduleApply(webState: WebPanelState, runtime: BrowserPanelRuntime) {
            guard lastAppliedWebState != webState,
                  pendingWebState != webState else {
                return
            }

            // Only the latest pending browser state should apply; superseded
            // snapshots are intentionally dropped before they reach the runtime.
            pendingWebState = webState
            let requestID = UUID()
            pendingApplyRequestID = requestID

            // Hop off updateNSView so BrowserPanelRuntime can publish its
            // navigation state without tripping SwiftUI's view-update warning.
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
            shouldFocusWebView: Bool,
            runtime: BrowserPanelRuntime
        ) {
            let shouldRequestFocus = Self.shouldRequestWebViewFocus(
                previousShouldFocusWebView: lastShouldFocusWebView,
                nextShouldFocusWebView: shouldFocusWebView
            )
            lastShouldFocusWebView = shouldFocusWebView

            guard shouldFocusWebView else {
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
            shouldFocusWebView: Bool,
            runtime: BrowserPanelRuntime
        ) {
            guard shouldFocusWebView,
                  pendingFocusRequestID != nil else {
                return
            }

            if runtime.focusWebView() {
                resetPendingFocusRequest()
            }
        }

        nonisolated static func shouldRequestWebViewFocus(
            previousShouldFocusWebView: Bool,
            nextShouldFocusWebView: Bool
        ) -> Bool {
            nextShouldFocusWebView && previousShouldFocusWebView == false
        }

        private func scheduleDeferredFocusRequest(runtime: BrowserPanelRuntime) {
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
                      self.lastShouldFocusWebView,
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
            lastShouldFocusWebView = false
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

        let attach = { (view: NSView) in
            runtime.attachHost(to: view, attachment: attachment)
            context.coordinator.retryPendingFocusIfNeeded(
                shouldFocusWebView: shouldFocusWebView,
                runtime: runtime
            )
        }

        containerView.onLayout = attach
        attach(containerView)
        runtime.setEffectivelyVisible(isEffectivelyVisible)

        context.coordinator.scheduleApply(webState: webState, runtime: runtime)
        context.coordinator.requestFocusIfNeeded(
            shouldFocusWebView: shouldFocusWebView,
            runtime: runtime
        )
    }

    static func dismantleNSView(_ containerView: WebPanelContainerView, coordinator: Coordinator) {
        containerView.onLayout = nil
        coordinator.reset()
    }
}
