import AppKit
import CoreState
import SwiftUI

struct BrowserPanelHostView: NSViewRepresentable {
    let panelID: UUID
    let webState: WebPanelState
    let webPanelRuntimeRegistry: WebPanelRuntimeRegistry

    @MainActor
    final class Coordinator {
        let containerCoordinator = PanelHostContainerCoordinator()

        func reset() {
            containerCoordinator.reset()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> BrowserPanelContainerView {
        BrowserPanelContainerView()
    }

    func updateNSView(_ containerView: BrowserPanelContainerView, context: Context) {
        let runtime = webPanelRuntimeRegistry.browserRuntime(
            for: panelID,
            state: webState
        )
        let attachment = context.coordinator.containerCoordinator.attachment(
            for: containerView,
            controller: runtime
        )

        let update = { (view: NSView) in
            runtime.update(
                webState: webState,
                sourceContainer: view,
                attachment: attachment
            )
        }

        containerView.onLayout = update
        update(containerView)
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
