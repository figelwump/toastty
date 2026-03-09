import AppKit
import CoreState
import SwiftUI

struct TerminalPanelHostView: NSViewRepresentable {
    let workspaceID: UUID
    let panelID: UUID
    let terminalState: TerminalPanelState
    let focused: Bool
    let globalFontPoints: Double
    let runtimeRegistry: TerminalRuntimeRegistry

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

    func makeNSView(context: Context) -> TerminalPanelContainerView {
        TerminalPanelContainerView()
    }

    func updateNSView(_ containerView: TerminalPanelContainerView, context: Context) {
        let coordinator = context.coordinator
        let controller = runtimeRegistry.controller(for: panelID, workspaceID: workspaceID)
        let attachment = coordinator.containerCoordinator.attachment(
            for: containerView,
            controller: controller
        )
        controller.attachHost(to: containerView, attachment: attachment)

        let update = { (view: NSView) in
            let scale = effectiveBackingScaleFactor(for: view)
            controller.update(
                terminalState: terminalState,
                focused: focused,
                fontPoints: globalFontPoints,
                viewportSize: view.bounds.size,
                backingScaleFactor: scale,
                sourceContainer: view,
                attachment: attachment
            )
        }

        containerView.onLayout = update
        update(containerView)
    }

    static func dismantleNSView(_ containerView: TerminalPanelContainerView, coordinator: Coordinator) {
        containerView.onLayout = nil
        coordinator.reset()
    }

    private func effectiveBackingScaleFactor(for view: NSView) -> CGFloat {
        if let screenScale = view.window?.screen?.backingScaleFactor {
            return max(screenScale, 1)
        }
        if let windowScale = view.window?.backingScaleFactor {
            return max(windowScale, 1)
        }
        if let mainScale = NSScreen.main?.backingScaleFactor {
            return max(mainScale, 1)
        }
        return 1
    }
}

final class TerminalPanelContainerView: NSView {
    var onLayout: ((NSView) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onLayout?(self)
    }
}
