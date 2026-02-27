import AppKit
import CoreState
import SwiftUI

struct TerminalPanelHostView: NSViewRepresentable {
    let panelID: UUID
    let terminalState: TerminalPanelState
    let focused: Bool
    let globalFontPoints: Double
    let runtimeRegistry: TerminalRuntimeRegistry

    func makeNSView(context: Context) -> TerminalPanelContainerView {
        TerminalPanelContainerView()
    }

    func updateNSView(_ containerView: TerminalPanelContainerView, context: Context) {
        let controller = runtimeRegistry.controller(for: panelID)
        controller.attach(into: containerView)

        let update = { (view: NSView) in
            let scale = view.window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            controller.update(
                terminalState: terminalState,
                focused: focused,
                fontPoints: globalFontPoints,
                viewportSize: view.bounds.size,
                backingScaleFactor: scale
            )
        }

        containerView.onLayout = update
        update(containerView)
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
}
