import AppKit

@MainActor
final class CommandPalettePanel: NSPanel {
    static let defaultFrame = NSRect(x: 0, y: 0, width: 580, height: 252)

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
        hasShadow = true
        isOpaque = false
        backgroundColor = .clear
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.moveToActiveSpace, .transient]
    }

    func position(relativeTo originWindow: NSWindow) {
        var frame = self.frame
        let originFrame = originWindow.frame
        frame.origin.x = originFrame.midX - (frame.width / 2)
        frame.origin.y = originFrame.maxY - (originFrame.height * 0.22) - frame.height
        setFrame(frame, display: false)
    }
}
