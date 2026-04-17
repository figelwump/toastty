import AppKit

@MainActor
final class CommandPalettePanel: NSPanel {
    static let defaultFrame = NSRect(x: 0, y: 0, width: 580, height: 252)
    static let cornerRadius: CGFloat = 12

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    init() {
        super.init(
            contentRect: Self.defaultFrame,
            styleMask: [.borderless, .fullSizeContentView],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .floating
        hasShadow = false
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.moveToActiveSpace, .transient]
        contentView?.wantsLayer = true
        contentView?.layer?.backgroundColor = NSColor.clear.cgColor
    }

    func position(relativeTo originWindow: NSWindow) {
        let frame = Self.positionedFrame(
            panelSize: self.frame.size,
            relativeTo: originWindow.frame,
            visibleFrame: originWindow.screen?.visibleFrame
        )
        setFrame(frame, display: false)
    }

    static func positionedFrame(
        panelSize: CGSize = defaultFrame.size,
        relativeTo originFrame: CGRect,
        visibleFrame: CGRect?
    ) -> CGRect {
        var frame = CGRect(
            x: originFrame.midX - (panelSize.width / 2),
            y: originFrame.midY - (panelSize.height / 2),
            width: panelSize.width,
            height: panelSize.height
        )

        guard let visibleFrame,
              visibleFrame.isEmpty == false,
              visibleFrame.isNull == false else {
            return frame.integral
        }

        frame.origin.x = min(
            max(frame.origin.x, visibleFrame.minX),
            visibleFrame.maxX - frame.width
        )
        frame.origin.y = min(
            max(frame.origin.y, visibleFrame.minY),
            visibleFrame.maxY - frame.height
        )
        return frame.integral
    }
}
