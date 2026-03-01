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
            let scale = effectiveBackingScaleFactor(for: view)
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
