import AppKit
import CoreState
import SwiftUI

struct MarkdownPanelHostView: NSViewRepresentable {
    @ObservedObject var runtime: MarkdownPanelRuntime
    let webState: WebPanelState

    @MainActor
    final class Coordinator {
        let containerCoordinator = PanelHostContainerCoordinator()
        var lastAppliedWebState: WebPanelState?

        func reset() {
            containerCoordinator.reset()
            lastAppliedWebState = nil
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
        }

        containerView.onLayout = attach
        attach(containerView)

        if context.coordinator.lastAppliedWebState != webState {
            runtime.apply(webState: webState)
            context.coordinator.lastAppliedWebState = webState
        }
    }

    static func dismantleNSView(_ containerView: WebPanelContainerView, coordinator: Coordinator) {
        containerView.onLayout = nil
        coordinator.reset()
    }
}
