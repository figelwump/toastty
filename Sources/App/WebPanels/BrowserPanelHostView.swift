import AppKit
import CoreState
import SwiftUI

struct BrowserPanelHostView: NSViewRepresentable {
    @ObservedObject var runtime: BrowserPanelRuntime
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

        if context.coordinator.lastAppliedWebState != webState {
            runtime.apply(webState: webState)
            context.coordinator.lastAppliedWebState = webState
        }
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
