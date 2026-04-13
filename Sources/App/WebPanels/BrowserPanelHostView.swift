import AppKit
import CoreState
import SwiftUI

struct BrowserPanelHostView: NSViewRepresentable {
    @ObservedObject var runtime: BrowserPanelRuntime
    let webState: WebPanelState

    @MainActor
    final class Coordinator {
        typealias MainActorScheduler = (@escaping @MainActor @Sendable () -> Void) -> Void

        let containerCoordinator = PanelHostContainerCoordinator()
        var lastAppliedWebState: WebPanelState?
        private var pendingWebState: WebPanelState?
        private var pendingApplyRequestID: UUID?
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

        func reset() {
            containerCoordinator.reset()
            lastAppliedWebState = nil
            pendingWebState = nil
            pendingApplyRequestID = nil
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BrowserPanelContainerView {
        BrowserPanelContainerView()
    }

    func updateNSView(_ containerView: BrowserPanelContainerView, context: Context) {
        let attachment = context.coordinator.containerCoordinator.attachment(
            for: containerView,
            controller: runtime
        )

        let attach = { (view: NSView) in
            runtime.attachHost(to: view, attachment: attachment)
        }

        containerView.onLayout = attach
        attach(containerView)

        context.coordinator.scheduleApply(webState: webState, runtime: runtime)
    }

    static func dismantleNSView(_ containerView: BrowserPanelContainerView, coordinator: Coordinator) {
        containerView.onLayout = nil
        coordinator.reset()
    }
}

final class BrowserPanelContainerView: NSView {
    var onLayout: ((NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        onLayout?(self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        onLayout?(self)
    }
}
